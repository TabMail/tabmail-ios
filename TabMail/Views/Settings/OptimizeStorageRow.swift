/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Settings > Email Index's Optimize Storage row (#1448): the size "Email Index Used"
/// can drop to, a line under it, and the tap. State and actions are `StorageOptimizer`'s.
///
/// The title stays on one line, and the size and the lines are grey, as other values in
/// Settings are. The size goes under the title, never beside it: beside it, it wraps on a
/// narrow row (a 375-pt phone from xxLarge up, or a phone that Display Zoom lays out 320 pt
/// wide, already at the default text size). Below the accessibility sizes the size and the
/// lines start where the title's text does. At the accessibility sizes a list wraps a label's
/// text under its icon and `LabeledContent` puts its value under its title, so the size and
/// the lines go under the title from the row's leading edge, as the rows around it do.
struct OptimizeStorageRow: View {
    let row: StorageOptimizer.Row
    /// Formats a size as "Email Index Used" shows it.
    let format: (Int64) -> String
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let title = "Optimize"
    static let overnightLine = "TabMail does this overnight. Tap to do it now."
    static let upgradeFirstLine = "Needs a one-time database upgrade first. Tap to start."
    static let failedLine = "Could not finish now. Nothing was lost. TabMail will try again overnight."
    static let optimizingTitle = "Optimizing…"

    static func canDropTo(_ size: String) -> String {
        "Can drop to \(size)"
    }

    /// The line under the row; none while the steps run.
    static func line(for row: StorageOptimizer.Row) -> String? {
        switch row {
        case .optimizing: nil
        case .upgradeFirst: upgradeFirstLine
        case .ready(_, let lastRunFailed): lastRunFailed ? failedLine : overnightLine
        }
    }

    private static let icon = "internaldrive"

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                if dynamicTypeSize.isAccessibilitySize {
                    titleLabel
                    trailing
                    if let line = Self.line(for: row) {
                        lineText(line)
                    }
                } else {
                    titleLabel
                    underTitle(trailing)
                    if let line = Self.line(for: row) {
                        underTitle(lineText(line))
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(row == .optimizing)
    }

    private var titleLabel: some View {
        Label(Self.title, systemImage: Self.icon)
            .lineLimit(1)
    }

    private func lineText(_ line: String) -> some View {
        Text(line)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
    }

    /// `content` in a label whose icon is the row's, hidden, so in the list it starts where
    /// the title's text does. The content's font is set inside it, never on the result: the
    /// label's own font sizes the hidden icon, and so the place the content starts.
    private func underTitle(_ content: some View) -> some View {
        Label {
            content
        } icon: {
            Image(systemName: Self.icon)
                .hidden()
        }
    }

    /// `Color.secondary`, not the `.secondary` style: inside the button that style is a lighter
    /// shade of the button's tint, not grey.
    @ViewBuilder
    private var trailing: some View {
        switch row {
        case .optimizing:
            HStack(spacing: 6) {
                ProgressView()
                Text(Self.optimizingTitle)
                    .foregroundStyle(Color.secondary)
            }
        case .upgradeFirst(let bytes), .ready(let bytes, _):
            Text(Self.canDropTo(format(bytes)))
                .foregroundStyle(Color.secondary)
        }
    }
}
