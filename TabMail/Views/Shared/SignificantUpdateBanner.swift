/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Banner offering Apple's significant update notice after an earlier one never
/// came back (issue #1010). Same shape as `SignInAgainBanner`: subtle, no dismiss
/// button (it clears once the notice returns), the tap action injected by the
/// caller. Shown only where `AppStoreAgeCheck` returned `.offerBanner`.
struct SignificantUpdateBanner: View {
    let version: String
    let onOpen: () -> Void

    static let title = "Significant update"
    static let actionTitle = "Review"

    static func message(version: String) -> String {
        "TabMail \(version) has changed. Review the update notice."
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textColor)
                Text(Self.message(version: version))
                    .font(.caption2)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(Self.actionTitle, action: onOpen)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
