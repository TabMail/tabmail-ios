/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Quiet row at the top of the inbox reminding a user on the card-free signup
/// trial how many days are left, with a button to the existing Choose a Plan
/// screen. Once the trial has ended it reads "Free trial ended" and can also
/// offer Feedback (the trial-feedback sheet). Not dismissible: it disappears by
/// itself when the user subscribes.
struct InboxTrialReminder: View {
    let text: String
    /// Shows a Feedback button before Plans when set.
    var onFeedback: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.footnote)
                .foregroundStyle(.blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(Palette.textColor)
            Spacer(minLength: 8)
            if let onFeedback {
                TrialFeedbackButton(action: onFeedback)
            }
            // Plans is the row's main action: a small filled capsule.
            Button("Plans") {
                NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // Tint the row only: by default a background bleeds into the safe
        // area and would tint the navigation and status bars above it.
        .background(Color.blue.opacity(0.08), ignoresSafeAreaEdges: [])
    }

    /// The row's text, or `nil` when the row must not show. Only a running
    /// signup trial (`TrialState.active`) in the signed-in, non-demo inbox shows
    /// it; a paid plan (including an Apple or Stripe subscription trial), BYOK,
    /// an ended trial and no trial all resolve to other states.
    nonisolated static func text(for trialState: TrialState, isInbox: Bool, isSignedIn: Bool, isDemo: Bool) -> String? {
        guard isInbox, isSignedIn, !isDemo, case .active(let days) = trialState else { return nil }
        return "Free trial · \(days) \(days == 1 ? "day" : "days") left"
    }

    /// The row's text once the signup trial has ENDED with no subscription,
    /// or `nil`. The same exclusions as `text(for:...)`: other folders, signed
    /// out and demo mode show nothing, and a subscriber, BYOK or an unknown
    /// state never resolve to `.ended`.
    nonisolated static func endedText(for trialState: TrialState, isInbox: Bool, isSignedIn: Bool, isDemo: Bool) -> String? {
        guard isInbox, isSignedIn, !isDemo, trialState == .ended else { return nil }
        return TrialFeedback.bannerEndedText
    }
}

/// The trial-ended banners' secondary action: a small gray bordered capsule
/// that opens the feedback sheet. Shared by the inbox row and the folder list
/// so both look the same, and set apart from the filled Plans capsule.
struct TrialFeedbackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(TrialFeedback.bannerFeedbackLabel, systemImage: TrialFeedback.bannerFeedbackSymbol)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .tint(.gray)
    }
}
