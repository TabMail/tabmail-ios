/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import TipKit

/// Grey bordered label chip — Gmail-style plain text chip for user labels.
/// Used in MessageRowView (inbox), MessageCardView (detail), and thread views.
struct UserLabelChip: View {
    let name: String

    init(userLabel: UserLabel) {
        self.name = userLabel.name
    }

    init(name: String) {
        self.name = name
    }

    /// Gmail-style: filled background pill, muted text. Adapts to light/dark mode.
    private static let chipBackground = Color(light: Color(hex: 0xE8E8ED), dark: Color(hex: 0x2C2C2E))
    private static let chipText = Color(light: Color(hex: 0x3C3C43), dark: Color(hex: 0xAEAEB2))
    private static let chipBorder = Color(light: Color(hex: 0xD1D1D6), dark: Color(hex: 0x48484A))

    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(1)
            .foregroundStyle(Self.chipText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.chipBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Self.chipBorder, lineWidth: 0.5)
            )
    }
}

/// Expand user labels into display segments — splits nested labels (e.g., "Work/Projects")
/// into individual segment names ["Work", "Projects"]. Each segment gets its own chip.
/// Returns (displayName, parentLabel) pairs so the parent UserLabel can be used for remove actions.
struct UserLabelDisplaySegment: Identifiable {
    let id: String  // Unique key for ForEach: "\(label.id):\(segment)"
    let displayName: String
    let parentLabel: UserLabel

    static func expand(_ labels: [UserLabel]) -> [UserLabelDisplaySegment] {
        var segments: [UserLabelDisplaySegment] = []
        var seenNames: Set<String> = []
        for label in labels {
            let parts = UserLabelStore.splitNestedLabelName(label.name)
            for part in parts {
                let lower = part.lowercased()
                guard seenNames.insert(lower).inserted else { continue } // Dedup
                segments.append(UserLabelDisplaySegment(
                    id: "\(label.id):\(part)",
                    displayName: part,
                    parentLabel: label
                ))
            }
        }
        return segments.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// TipKit tooltip shown on first encounter with a user label chip.
/// Same pattern as TagTeachingTip used on action tag badges.
/// Tip for inbox rows — shown on first label chip appearance.
struct UserLabelRowManageTip: Tip {
    var title: Text {
        Text("Labels")
    }
    var message: Text? {
        Text("Long-hold a message to manage labels.")
    }
}

/// Tip for message detail cards — shown on first label chip appearance.
struct UserLabelCardManageTip: Tip {
    var title: Text {
        Text("Labels")
    }
    var message: Text? {
        Text("Long-hold the subject to manage labels.")
    }
}
