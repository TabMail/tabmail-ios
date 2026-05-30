/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Compact tag indicator: colored square with optional single letter.
/// Green "R" (reply), Yellow "A" (archive), Red "D" (delete), Blue no letter (none).
struct TagBadge: View {
    let tag: ActionTag

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.tagColor(tag))
                .frame(width: 12, height: 12)
            if let letter = tag.letter {
                Text(letter)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Embossed button look for tappable action-tag badges (subtle gradient,
/// top highlight, hairline border, soft colored drop shadow).
struct ActionTagButtonStyle: ViewModifier {
    let color: Color
    var cornerRadius: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    LinearGradient(
                        colors: [color, color.opacity(0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.clear,
                            Color.black.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.7),
                                Color.white.opacity(0.2),
                                Color.black.opacity(0.4)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: color.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }
}

extension View {
    func actionTagButtonStyle(color: Color, cornerRadius: CGFloat = 4) -> some View {
        modifier(ActionTagButtonStyle(color: color, cornerRadius: cornerRadius))
    }
}
