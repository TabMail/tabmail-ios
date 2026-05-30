/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Gmail-style toast for the undo-send buffer.
///
/// - Phase 1 (0 → outboxUndoHoldSeconds): "Sending. To: …" with a left→right
///   progress bar filling under the label; Undo button active.
/// - Phase 2 (outboxUndoHoldSeconds → total): "✓ Message sent"; no Undo button;
///   the 1 s claim buffer and the 1.5 s confirmation window are visually fused
///   into a single "sent" phase lasting 2.5 s.
///
/// Uses `TimelineView(.animation)` so phase rendering is driven by wall-clock
/// time — no lifecycle state machine, no ScenePhase reconciliation, and
/// backgrounding "just works" (on foreground the view recomputes from the
/// latest `Date()`).
struct PendingSendToast: View {
    let pending: PendingSendService.Pending
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(pending.queuedAt)
            let undoDeadline = SyncConfig.outboxUndoHoldSeconds

            if elapsed < undoDeadline {
                // `remaining` = fraction of undo-hold time left. Starts at 1
                // (bar full) and drains to 0 (bar empty) — a visual cue that
                // the window is closing.
                let remaining = max(0, 1 - elapsed / undoDeadline)
                phase1(progress: remaining)
            } else {
                phase2
            }
        }
    }

    // MARK: - Phase 1: holding + progress + Undo

    private func phase1(progress: Double) -> some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 12) {
                Text("Sending. \(pending.toSummary)")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button("Undo") { onUndo() }
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

            // Thin progress bar along the bottom edge of the capsule.
            GeometryReader { geo in
                Rectangle()
                    .fill(Palette.archive.opacity(0.8))
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 2)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
        .background(
            Capsule()
                .fill(Color(hex: 0x323232))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .clipShape(Capsule())
        .padding(.horizontal, 16)
    }

    // MARK: - Phase 2: confirmation

    private var phase2: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.archive)
                .font(.subheadline)
            Text("Message sent")
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
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
