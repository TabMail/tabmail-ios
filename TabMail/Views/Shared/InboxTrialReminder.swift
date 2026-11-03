/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Quiet row at the top of the inbox reminding a user on the card-free signup
/// trial how many days are left, with a button to the existing Choose a Plan
/// screen. Not dismissible: it disappears by itself when the trial ends or the
/// user subscribes.
struct InboxTrialReminder: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.footnote)
                .foregroundStyle(.blue)
            Text(text)
                .font(.caption)
                .foregroundStyle(Palette.textColor)
            Spacer(minLength: 8)
            Button("Plans") {
                NotificationCenter.default.post(name: .navigateToPlanPicker, object: nil)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity(0.08))
    }

    /// The row's text, or `nil` when the row must not show. Only a running
    /// signup trial (`TrialState.active`) in the signed-in, non-demo inbox shows
    /// it; a paid plan (including an Apple or Stripe subscription trial), BYOK,
    /// an ended trial and no trial all resolve to other states.
    nonisolated static func text(for trialState: TrialState, isInbox: Bool, isSignedIn: Bool, isDemo: Bool) -> String? {
        guard isInbox, isSignedIn, !isDemo, case .active(let days) = trialState else { return nil }
        return "Free trial · \(days) \(days == 1 ? "day" : "days") left"
    }
}
