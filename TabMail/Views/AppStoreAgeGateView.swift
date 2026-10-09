/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Full-screen refusal shown over everything else while the App Store reports
/// a minor, or cannot confirm an age in a regulated region.
struct AppStoreAgeGateView: View {
    let status: AppStoreAgeCheck.Status
    let onRetry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("TabMailLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200)

            Text(status == .minor ? "TabMail isn\u{2019}t available for your account" : "We need to confirm your age")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text(status == .minor
                ? "Based on the age information in your Apple Account, you aren\u{2019}t able to use TabMail."
                : "In your region, TabMail must confirm your age range with the App Store. Make sure you\u{2019}re signed in to your Apple Account and allow sharing when asked, then try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()

            if status == .unconfirmed {
                Button {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        await onRetry()
                        isRetrying = false
                    }
                } label: {
                    Group {
                        if isRetrying {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Try Again")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isRetrying)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .background(Palette.previewPaneBg)
        .lockOrientation(.portrait)
    }
}
