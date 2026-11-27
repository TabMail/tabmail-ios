/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// An email bubble's Details pin: "Details" and a chevron under the words, at the bubble's trailing
/// edge (`ChatBubbleStack`). Every bubble of the user's email and of an email in the chat shows it
/// (ADR-IOS-114), so a bubble keeps its look as it turns from the user's message into the Sending
/// bubble and into the email's own bubble:
/// - active where the bubble opens the email (the tap is the bubble's own);
/// - inactive, dimmed and not tappable, where there is nothing to open yet (the user's message while
///   its email is written, the email while it is sending).
///
/// Active and inactive take the same size, so a bubble keeps its size when its pin turns active.
/// VoiceOver skips it: the bubble's own label and hint say what a tap does.
struct ChatDetailsPin: View {
    let isActive: Bool
    /// The pin's color when active (`ownColor(on:)` on the user's blue).
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text("Details")
            Image(systemName: "chevron.right")
        }
        .font(.caption2)
        .foregroundStyle(color)
        .opacity(Self.opacity(isActive: isActive))
        .allowsHitTesting(isActive)
        .accessibilityHidden(true)
    }

    /// The pin's opacity over its color: full when active, dimmed when inactive.
    static func opacity(isActive: Bool) -> Double {
        isActive ? 1 : ChatViewLayout.detailsPinInactiveOpacity
    }

    /// The pin's color on a bubble whose words are `textColor` (the user's blue bubbles).
    static func ownColor(on textColor: Color) -> Color {
        textColor.opacity(ChatViewLayout.detailsPinOwnOpacity)
    }
}
