/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

struct UndoToast: View {
    let label: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Button("Undo") {
                onUndo()
            }
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(Palette.archive)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(Color(hex: 0x323232))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .padding(.horizontal, 16)
    }
}
