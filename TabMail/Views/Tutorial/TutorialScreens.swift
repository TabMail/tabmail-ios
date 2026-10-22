/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// The first screen of a fresh install, before sign-in (owner V5). Shown once:
/// Start, Skip and Sign in all dismiss it for good.
struct TutorialWelcomeView: View {
    var onStart: () async -> Void
    /// Skip and "I have an account · Sign in": both open the sign-in screen.
    var onSkip: () -> Void

    @State private var isStarting = false

    var body: some View {
        TutorialPage {
            Image("TabMailLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 160)

            Text("A little practice.\nLess time on email.")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text("Try TabMail on sample emails before you sign in.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                TutorialBenefit(symbol: "hand.tap", title: "Act with a tap", detail: "Tags are buttons. Hold one to change it.")
                TutorialBenefit(symbol: "arrowshape.turn.up.left", title: "Reuse your best replies", detail: "Turn a reply into a template.")
                TutorialBenefit(symbol: "magnifyingglass", title: "Ask anything", detail: "Find past email and more.")
            }
            .padding(.vertical, 8)

            Label("Sample emails only. Nothing is sent.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        } footer: {
            TutorialPrimaryButton(title: "Give it a quick try", isLoading: isStarting) {
                isStarting = true
                Task {
                    await onStart()
                    isStarting = false
                }
            }
            .accessibilityIdentifier("tutorial-welcome-start")
            HStack(spacing: 24) {
                Button("Skip", action: onSkip)
                Button("I have an account · Sign in", action: onSkip)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .disabled(isStarting)
        }
    }
}

/// The closing recap. Its button ends the tutorial: the demo is cleaned up,
/// then sign-in (new user) or the restored inbox opens.
struct TutorialFinishView: View {
    let signedIn: Bool
    @State private var isEnding = false

    var body: some View {
        TutorialPage {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.reply)

            Text("You’re ready.")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            Text("Three things to try in your own inbox:")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("Tap a tag to act. Hold it to change.", systemImage: "checkmark")
                Label("Turn a good reply into a template.", systemImage: "checkmark")
                Label("Ask TabMail anything.", systemImage: "checkmark")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 8)

            Text("Practice changes stay in the demo.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        } footer: {
            TutorialPrimaryButton(
                title: signedIn ? "Back to my inbox" : "Continue to sign in",
                isLoading: isEnding
            ) {
                isEnding = true
                Task { await TutorialCoordinator.shared.end() }
            }
            .accessibilityIdentifier("tutorial-finish")
        }
    }
}

// MARK: - Shared layout

/// Full-screen tutorial page: centered content that scrolls, and a footer.
private struct TutorialPage<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(.horizontal, 32)
                .padding(.top, 56)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 14) {
                footer
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }
}

private struct TutorialBenefit: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TutorialPrimaryButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().tint(.white) }
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
    }
}

/// The sidebar tutorial row (owner V5): progress at the top of the app
/// section until every part is done, then nothing (replay is in the debug
/// menu, owner 2026-10-21). No pop-ups or badges.
struct TutorialSidebarRow: View {
    let state: TutorialRowState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tutorial")
                        Text("\(state.done) of \(state.total) done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "graduationcap")
                }
                ProgressView(value: Double(state.done), total: Double(state.total))
                    .tint(Theme.accent)
                    .padding(.leading, 8)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .accessibilityIdentifier("tutorial-sidebar-row")
    }
}
