/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Wrapping flow layout — places items left-to-right, wrapping to the next row when space runs out.
/// Used by MarkdownChatText for inline email pills mixed with text segments.
/// Text segments are width-constrained so they wrap within the available space.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 2

    private struct Entry {
        let position: CGPoint
        let proposal: ProposedViewSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, entry) in result.entries.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + entry.position.x, y: bounds.minY + entry.position.y),
                proposal: entry.proposal
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (entries: [Entry], totalSize: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var entries: [Entry] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let remaining = maxWidth - x

            // Use ideal (unconstrained) width for wrap decision.
            // Text.sizeThatFits with a narrow width always "fits" by wrapping vertically,
            // so constrained measurement would never trigger a line break.
            let idealSize = subview.sizeThatFits(.unspecified)

            if idealSize.width > remaining && x > 0 {
                // Doesn't fit on current row — wrap to next line
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }

            // Place with width constraint so text wraps within available space
            let lineWidth = maxWidth - x
            let placeProposal = ProposedViewSize(width: lineWidth, height: nil)
            let placedSize = subview.sizeThatFits(placeProposal)

            entries.append(Entry(position: CGPoint(x: x, y: y), proposal: placeProposal))
            x += placedSize.width + hSpacing
            rowHeight = max(rowHeight, placedSize.height)
        }

        return (entries, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
