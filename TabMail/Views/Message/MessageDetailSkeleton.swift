/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Placeholder layout shown while the opened message's header resolves
/// asynchronously. `MessageDetailViewModel.init` is zero-I/O (it seeds only
/// from the in-memory NSE staged snapshot), so a non-staged open renders this
/// for the few ms until `loadBody`'s async resolve populates `message` — and
/// for however long a cold/saturated-I/O resolve genuinely takes, during
/// which the main actor stays responsive instead of stalling on a sync read.
/// Mirrors the real detail structure (sender card → subject → body lines) so
/// the swap to content doesn't jump; the house shimmer sweeps over it so the
/// wait reads as loading.
struct MessageDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(.systemFill))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 7) {
                    bar(width: 150, height: 13)
                    bar(width: 96, height: 10)
                }
                Spacer()
            }
            bar(width: 250, height: 17)
            VStack(alignment: .leading, spacing: 11) {
                bar(height: 11)
                bar(height: 11)
                bar(width: 210, height: 11)
                bar(height: 11)
                bar(width: 160, height: 11)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .aiWorkingShimmer(active: true, cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading message")
    }

    /// One placeholder bar; `width: nil` fills the available width.
    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color(.systemFill))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
