/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Inbox banner while the one-time database upgrade has not run
/// (`DatabaseUpgrade.needsUpgrade`, ADR-IOS-121). Same shape as `SignInAgainBanner`
/// and `SignificantUpdateBanner`: subtle, no dismiss button (it clears once both
/// databases are upgraded), the tap action injected by the caller (it opens the
/// upgrade notice).
struct DatabaseUpgradeBanner: View {
    let onOpen: () -> Void

    static let title = "Database update"
    static let message = "For the best experience, TabMail needs to update your database."
    static let actionTitle = "Update"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.footnote)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textColor)
                Text(Self.message)
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
