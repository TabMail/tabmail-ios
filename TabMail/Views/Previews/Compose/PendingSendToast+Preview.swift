/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI

// Previews for the undo-send toast.
// The toast is TimelineView-driven and renders its phase from
// `Date().timeIntervalSince(pending.queuedAt)`. We fake `queuedAt` at
// various offsets so the canvas shows each phase without waiting 5+ seconds.
//
// Phase 1 (elapsed < 5 s): "Sending. To: …" with progress bar + Undo.
// Phase 2 (elapsed ≥ 5 s): "✓ Message sent" (no Undo).

@MainActor
private func previewToast(
    elapsed: TimeInterval,
    toSummary: String = "To: alice@example.com"
) -> some View {
    let queuedAt = Date().addingTimeInterval(-elapsed)
    let pending = PendingSendService.Pending(
        id: "preview-outbox-id",
        draftId: "preview-draft-id",
        toSummary: toSummary,
        queuedAt: queuedAt
    )
    return PendingSendToast(
        pending: pending,
        onUndo: { print("[Preview] Undo tapped") },
        onDismiss: { print("[Preview] × tapped") }
    )
}

#Preview("Phase 1 — just sent (0 s elapsed)") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(elapsed: 0)
    }
}

#Preview("Phase 1 — mid progress (~2.5 s elapsed, 50% fill)") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(elapsed: 2.5)
    }
}

#Preview("Phase 1 — near end (~4.8 s elapsed)") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(elapsed: 4.8)
    }
}

#Preview("Phase 2 — '✓ Message sent' (6 s elapsed)") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(elapsed: 6)
    }
}

#Preview("Phase 1 — multi-recipient summary") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(elapsed: 2, toSummary: "To: alice@example.com, bob@company.co +3")
    }
}

#Preview("Phase 1 — long recipient name (line-limit test)") {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        previewToast(
            elapsed: 1,
            toSummary: "To: very-long-email-address-for-testing-truncation@subdomain.example-company.com"
        )
    }
}
#endif
