/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Shared indicator icons for message rows across InboxView, MessageDetailView, and thread views.
enum MessageIndicators {
    /// Merged reply/forward icon: single slot instead of two.
    /// - Both replied & forwarded: overlapped arrows icon
    /// - Replied only: reply arrow
    /// - Forwarded only: forward arrow
    /// - Neither: invisible placeholder (preserves layout)
    @ViewBuilder
    static func replyForwardIcon(isReplied: Bool, isForwarded: Bool, size: CGFloat) -> some View {
        if isReplied && isForwarded {
            // Both: use a combined arrows icon
            Image(systemName: "arrowshape.turn.up.left.right.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
        } else if isReplied {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
        } else if isForwarded {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
        } else {
            // Invisible placeholder to maintain consistent spacing
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
                .opacity(0)
        }
    }
}
