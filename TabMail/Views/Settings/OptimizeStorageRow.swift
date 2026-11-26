/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Settings > Email Index's Optimize Storage row (#1448): the size "Email Index Used"
/// can drop to, a line under it, and the tap. State and actions are `StorageOptimizer`'s.
struct OptimizeStorageRow: View {
    let row: StorageOptimizer.Row
    /// Formats a size as "Email Index Used" shows it.
    let format: (Int64) -> String
    let onTap: () -> Void

    static let title = "Optimize Storage"
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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(Self.title, systemImage: "internaldrive")
                    Spacer()
                    trailing
                }
                if let line = Self.line(for: row) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(row == .optimizing)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row {
        case .optimizing:
            HStack(spacing: 6) {
                ProgressView()
                Text(Self.optimizingTitle)
                    .foregroundStyle(.secondary)
            }
        case .upgradeFirst(let bytes), .ready(let bytes, _):
            Text(Self.canDropTo(format(bytes)))
                .foregroundStyle(.secondary)
        }
    }
}
