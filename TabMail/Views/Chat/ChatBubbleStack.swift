/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// An email bubble's content: its words, then its Details pin under them at the bubble's trailing
/// edge. As wide as the wider of the two and no wider, so a short email's bubble hugs its words as
/// a Sending bubble does, and a long one wraps at the width it is offered. A stack with a spacer
/// before the pin would take every bubble to that whole width.
///
/// The first subview is the words, at the leading edge; the last is the pin, at the trailing edge.
struct ChatBubbleStack: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = Self.sizes(of: subviews, width: proposal.width)
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.sizes(of: subviews, width: bounds.width)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            let isPin = index == subviews.count - 1 && subviews.count > 1
            let x = isPin ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            y += size.height + spacing
        }
    }

    /// Each subview's size within `width`: the words wrap there, the pin keeps its own size.
    private static func sizes(of subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }
}
